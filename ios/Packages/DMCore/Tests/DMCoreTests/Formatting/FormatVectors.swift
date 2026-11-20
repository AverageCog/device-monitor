import Foundation
@testable import DMCore

/// Fixtures/models/formatting-vectors.json: inputs and outputs of the dashboard's own formatters,
/// recorded by running the JavaScript in Node.
struct FormatVectors: Decodable {
    /// A JavaScript value as the file writes it.
    enum Value: Decodable, CustomStringConvertible {
        case number(Double)
        case string(String)
        case null
        case undefined
        /// A numeric result, kept as its IEEE-754 bits so the comparison is exact.
        case bits(UInt64, String)

        private enum Keys: String, CodingKey {
            case special = "$", bits, str
        }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let number = try? single.decode(Double.self) {
                self = .number(number)
            } else if let string = try? single.decode(String.self) {
                self = .string(string)
            } else {
                let object = try decoder.container(keyedBy: Keys.self)
                if let hex = try object.decodeIfPresent(String.self, forKey: .bits) {
                    guard let bits = UInt64(hex, radix: 16) else {
                        throw DecodingError.dataCorruptedError(forKey: .bits, in: object, debugDescription: "Not hex")
                    }
                    self = .bits(bits, try object.decode(String.self, forKey: .str))
                    return
                }
                switch try object.decode(String.self, forKey: .special) {
                case "NaN": self = .number(.nan)
                case "Infinity": self = .number(.infinity)
                case "-Infinity": self = .number(-.infinity)
                case "-0": self = .number(-0.0)
                case "undefined": self = .undefined
                case let other:
                    throw DecodingError.dataCorruptedError(forKey: .special, in: object, debugDescription: "Unknown special value \(other)")
                }
            }
        }

        /// The argument as a number; null and undefined are nil.
        var double: Double? {
            if case .number(let value) = self { return value }
            return nil
        }

        var text: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var description: String {
            switch self {
            case .number(let value): JS.string(value) + (value == 0 && value.sign == .minus ? " (-0)" : "")
            case .string(let value): "\"\(value)\""
            case .null: "null"
            case .undefined: "undefined"
            case .bits(_, let text): text
            }
        }
    }

    /// `[arguments, result]`, with the time zone (or the dashboard colour) as an optional third item.
    struct Row: Decodable {
        let args: [Value]
        let out: Value
        let extra: String?

        init(from decoder: Decoder) throws {
            var items = try decoder.unkeyedContainer()
            args = try items.decode([Value].self)
            out = try items.decode(Value.self)
            extra = items.isAtEnd ? nil : try items.decode(String.self)
        }

        func number(_ index: Int) -> Double? {
            index < args.count ? args[index].double : nil
        }

        func text(_ index: Int) -> String? {
            index < args.count ? args[index].text : nil
        }
    }

    /// A number as the file spells it and the bits Node says it has.
    struct Spelled: Decodable {
        let value: Double
        let bits: UInt64

        init(from decoder: Decoder) throws {
            var items = try decoder.unkeyedContainer()
            value = try items.decode(Double.self)
            bits = UInt64(try items.decode(String.self), radix: 16) ?? 0
        }
    }

    let locale: String
    let now: Double
    let doubles: [Spelled]
    let cases: [String: [Row]]

    static func load() throws -> FormatVectors {
        try JSONDecoder().decode(FormatVectors.self, from: try Fixture.data("models/formatting-vectors.json"))
    }

    /// Node (ICU 78) puts a plain space before AM/PM and after a currency code; Apple's ICU puts
    /// U+202F and U+00A0 there. They are the same text to a reader, so both sides are compared
    /// with those folded to a space. Nothing else is normalised.
    static func foldSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{A0}", with: " ")
    }
}
