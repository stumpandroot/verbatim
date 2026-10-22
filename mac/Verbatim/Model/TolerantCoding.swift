import Foundation

// Reading files a newer build wrote: unknown enum cases map to a fallback (and their raw value is kept to write
// back), and unknown keys are kept as they are and written back on save, so an older build never drops what it
// doesn't understand. Pure Foundation, so mac/tools/test-transcript.sh checks it on Linux.

/// Any JSON value, kept as it was read.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// A coding key made from any string.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// What a decode kept for writing back: keys this build doesn't know, and the raw values of enum fields whose case
/// it doesn't know (each with the fallback it read them as).
struct UnknownFields: Equatable {
    var keys: [String: JSONValue] = [:]
    /// Field name → (the raw value in the file, the fallback's raw value it was read as).
    var rawEnums: [String: RawEnum] = [:]

    struct RawEnum: Equatable {
        var raw: String
        var readAs: String
    }

    var isEmpty: Bool { keys.isEmpty && rawEnums.isEmpty }

    /// Every key in the decoder's container that isn't one of `known`.
    static func collect(from decoder: Decoder, known: Set<String>) -> [String: JSONValue] {
        guard let c = try? decoder.container(keyedBy: AnyCodingKey.self) else { return [:] }
        var out: [String: JSONValue] = [:]
        for k in c.allKeys where !known.contains(k.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: k) { out[k.stringValue] = v }
        }
        return out
    }

    /// Writes the kept keys (never over a key this build wrote).
    func encodeKeys(to encoder: Encoder, known: Set<String>) throws {
        guard !keys.isEmpty else { return }
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (k, v) in keys where !known.contains(k) { try c.encode(v, forKey: AnyCodingKey(k)) }
    }

    /// The raw value to write for an enum field: the file's own unknown value while the field still holds the
    /// fallback it was read as, otherwise the field's value.
    func raw(for field: String, current: String) -> String {
        guard let r = rawEnums[field], r.readAs == current else { return current }
        return r.raw
    }
}

/// An enum with string raw values that reads an unknown value (from a newer build) as `fallback` instead of failing.
protocol TolerantEnum: RawRepresentable where RawValue == String {
    static var fallback: Self { get }
}

extension TolerantEnum {
    /// Decodes a raw string tolerantly. Nil when the key is absent (or null); the fallback for an unknown value,
    /// noting the raw value in `unknown` under `field`.
    static func decodeTolerantly<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K, field: String,
                                               unknown: inout UnknownFields) -> Self? {
        guard let raw = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        if let v = Self(rawValue: raw) { return v }
        unknown.rawEnums[field] = .init(raw: raw, readAs: fallback.rawValue)
        return fallback
    }

    /// For a nested enum's own `init(from:)`: an unknown value reads as the fallback.
    static func tolerantValue(from decoder: Decoder) throws -> Self {
        let raw = try decoder.singleValueContainer().decode(String.self)
        return Self(rawValue: raw) ?? fallback
    }
}
