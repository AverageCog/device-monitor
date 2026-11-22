import Foundation

extension HubClient {
    /// JSON as the hub writes it, made acceptable to Foundation.
    ///
    /// The hub cuts strings by UTF-16 length (`str()` in `security.js`: `s.slice(0, max)`), which
    /// can leave half of a surrogate pair at the end of a hostname, an OS name or a label.
    /// `JSON.stringify` writes that half as an escape such as `\ud83d`. Browsers read it back
    /// without complaint; `JSONDecoder` and `JSONSerialization` refuse the whole document, so one
    /// such device would hide every other. Each unpaired escape becomes the escape for U+FFFD,
    /// which is what `String.prototype.toWellFormed()` makes of it. Everything else is returned
    /// byte for byte.
    static func wellFormedJSON(_ json: Data) -> Data {
        // Nearly every document has nothing to repair and comes back as it is, without a copy.
        guard let first = json.withUnsafeBytes({ unpairedSurrogateEscape(in: $0, from: 0) }) else { return json }
        var repaired = json
        repaired.withUnsafeMutableBytes { bytes in
            var next: Int? = first
            while let offset = next {
                // Only the four hex digits change ("fffd"), so nothing else moves.
                bytes[offset + 2] = UInt8(ascii: "f")
                bytes[offset + 3] = UInt8(ascii: "f")
                bytes[offset + 4] = UInt8(ascii: "f")
                bytes[offset + 5] = UInt8(ascii: "d")
                next = unpairedSurrogateEscape(in: UnsafeRawBufferPointer(bytes), from: offset + 6)
            }
        }
        return repaired
    }

    /// Where the next `\uXXXX` escape that is half of a surrogate pair, without its other half,
    /// begins. `from` must not be inside an escape.
    private static func unpairedSurrogateEscape(in bytes: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        var at = from
        // In JSON a backslash only occurs inside a string, where it escapes what follows it, so
        // walking from backslash to backslash sees every escape and never the tail of `\\`.
        while at < bytes.count, let found = memchr(base + at, 0x5C, bytes.count - at) {
            at = base.distance(to: UnsafeRawPointer(found))
            guard let unit = escapedCodeUnit(in: bytes, at: at) else {
                at += 2
                continue
            }
            switch unit {
            case 0xD800...0xDBFF:
                guard let other = escapedCodeUnit(in: bytes, at: at + 6), (0xDC00...0xDFFF).contains(other) else { return at }
                at += 12
            case 0xDC00...0xDFFF:
                return at
            default:
                at += 6
            }
        }
        return nil
    }

    /// The code unit of a complete `\uXXXX` escape beginning at `at`.
    private static func escapedCodeUnit(in bytes: UnsafeRawBufferPointer, at: Int) -> UInt16? {
        guard at + 6 <= bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") else { return nil }
        var unit: UInt16 = 0
        for index in (at + 2)..<(at + 6) {
            let digit: UInt8
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = bytes[index] - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = bytes[index] - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = bytes[index] - UInt8(ascii: "A") + 10
            default: return nil
            }
            unit = unit << 4 | UInt16(digit)
        }
        return unit
    }
}
