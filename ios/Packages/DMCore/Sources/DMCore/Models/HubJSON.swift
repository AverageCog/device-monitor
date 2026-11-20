import Foundation

/// The one JSON configuration every caller shares, so requests and responses agree with the hub.
///
/// Field names mirror the wire and timestamps stay as milliseconds since 1970, so neither a key
/// strategy nor a date strategy is set.
public enum HubJSON {
    public static var decoder: JSONDecoder { JSONDecoder() }

    /// Sorted keys make the same value always encode to the same bytes.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Decodes a top-level array (`GET /api/devices`, `GET /api/mobile`), dropping any element that
    /// does not decode. Throws only when the data is not a JSON array at all.
    public static func decodeList<T: Decodable>(_ type: T.Type = T.self, from data: Data) throws -> [T] {
        try decoder.decode([WireLenient<T>].self, from: data).compactMap(\.value)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
}

extension Date {
    /// A hub timestamp: milliseconds since 1970, as `Date.now()` in JavaScript.
    public init(hubTime milliseconds: Double) {
        self.init(timeIntervalSince1970: milliseconds / 1000)
    }

    public var hubTime: Double { (timeIntervalSince1970 * 1000).rounded() }
}

// MARK: - Tolerant decoding

/// Decodes to nil instead of throwing, so one bad entry cannot spoil a whole array or dictionary.
struct WireLenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// An integer the hub may have written as `3` or `3.0`.
struct WireInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let exact = try? container.decode(Int.self) {
            value = exact
            return
        }
        let number = try container.decode(Double.self)
        guard number.isFinite, abs(number) < 9e15 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an integer")
        }
        value = Int(number.rounded())
    }
}

/// The fields of one JSON object, read the way every model reads them: a newer hub may add, drop
/// or retype fields, and whatever cannot be read degrades to "absent" instead of failing the
/// payload it sits in. Only `require` throws.
struct WireFields<Key: CodingKey> {
    private let container: KeyedDecodingContainer<Key>

    init(_ decoder: Decoder, _ keys: Key.Type) throws {
        container = try decoder.container(keyedBy: keys)
    }

    /// For the few fields a value is meaningless without (a device's id, a point's time).
    func require<T: Decodable>(_ key: Key, as type: T.Type = T.self) throws -> T {
        try container.decode(T.self, forKey: key)
    }

    /// nil when the key is missing, null or holds something else than `T`.
    func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        try? container.decodeIfPresent(T.self, forKey: key)
    }

    func number(_ key: Key) -> Double? {
        guard let value = optional(key, as: Double.self), value.isFinite else { return nil }
        return value
    }

    func integer(_ key: Key) -> Int? {
        optional(key, as: WireInt.self)?.value
    }

    func text(_ key: Key) -> String? {
        optional(key, as: String.self)
    }

    func flag(_ key: Key) -> Bool? {
        optional(key, as: Bool.self)
    }

    /// Elements that do not decode are dropped; a missing or malformed array is empty.
    func list<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        listIfPresent(key, of: type) ?? []
    }

    /// As `list`, but keeps "no array at all" apart from "an empty array".
    func listIfPresent<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T]? {
        optional(key, as: [WireLenient<T>].self)?.compactMap(\.value)
    }

    /// Numbers whose position matters (energy buckets): an unreadable entry counts as zero rather
    /// than shifting everything after it.
    func alignedNumbers(_ key: Key) -> [Double]? {
        optionalNumbers(key)?.map { $0 ?? 0 }
    }

    /// Numbers whose position matters and where "not measured" is itself information (CPU cores).
    func optionalNumbers(_ key: Key) -> [Double?]? {
        optional(key, as: [WireLenient<Double>].self)?.map { entry in
            guard let value = entry.value, value.isFinite else { return nil }
            return value
        }
    }

    /// Entries whose value does not decode are dropped; a missing or malformed object is empty.
    func dictionary<V: Decodable>(_ key: Key, of type: V.Type = V.self) -> [String: V] {
        optional(key, as: [String: WireLenient<V>].self)?.compactMapValues(\.value) ?? [:]
    }
}
