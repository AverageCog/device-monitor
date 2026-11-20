import Foundation

/// A hub address: a bare HTTPS origin. Port of `origin()` in `transport.js`.
///
/// The JavaScript leans on the WHATWG URL parser and then checks the result. This parser is
/// stricter on input and produces the same serialisation (`new URL(x).origin`) for everything it
/// accepts, which matters because the origin string is an input to the TLS rotation proof:
/// - scheme `https` only (any case), no userinfo, no path beyond one optional `/`, no query, no fragment;
/// - host is a DNS name over `[a-z0-9.-]` (lowercased; internationalised names must already be in
///   their `xn--` form, which is how a hub prints them), a dotted-decimal IPv4 address, or a
///   bracketed IPv6 address (re-serialised in canonical form);
/// - an explicit port is kept, except 443 which an origin never shows.
public struct HubOrigin: Hashable, Sendable {
    /// `https://host` or `https://host:port`, exactly what the hub calls its origin.
    public let string: String
    /// The host as written in the origin: a lowercase name, an IPv4 address or a bracketed IPv6 address.
    public let host: String
    /// The explicit port; nil means 443.
    public let port: Int?

    /// Throws `HubError.invalidOrigin` unless `text` is a bare HTTPS origin.
    public init(_ text: String) throws {
        try self.init(text, allowTrailingSlash: true)
    }

    init(_ text: String, allowTrailingSlash: Bool) throws {
        var rest = Substring(text)
        guard rest.utf8.count <= 300, rest.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
              rest.count >= 8, rest.prefix(8).lowercased() == "https://" else { throw HubError.invalidOrigin }
        rest = rest.dropFirst(8)
        if allowTrailingSlash, rest.hasSuffix("/") { rest = rest.dropLast() }

        let hostText: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw HubError.invalidOrigin }
            hostText = rest[...close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { throw HubError.invalidOrigin }
                portText = after.dropFirst()
            }
        } else if let colon = rest.firstIndex(of: ":") {
            hostText = rest[..<colon]
            portText = rest[rest.index(after: colon)...]
        } else {
            hostText = rest
        }

        var port: Int?
        if let portText {
            // No sign, no leading zero, nothing a person would not write.
            guard (1...5).contains(portText.count), portText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  !portText.hasPrefix("0"), let number = Int(portText), number <= 65535 else { throw HubError.invalidOrigin }
            port = number == 443 ? nil : number
        }

        let host = try hostText.hasPrefix("[") ? Self.ipv6(hostText) : Self.nameOrIPv4(hostText)
        self.host = host
        self.port = port
        self.string = "https://" + host + (port.map { ":\($0)" } ?? "")
    }

    /// The URL of an absolute path (and optional, already encoded query) on this origin.
    func url(path: String, query: String? = nil) -> URL? {
        let text = string + path + (query.map { "?" + $0 } ?? "")
        guard let url = URL(string: text), url.absoluteString == text, url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func nameOrIPv4(_ text: Substring) throws -> String {
        let host = text.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...253).contains(host.utf8.count), labels.allSatisfy({ (1...63).contains($0.utf8.count) }),
              host.utf8.allSatisfy({ isLowerAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }),
              let last = labels.last else { throw HubError.invalidOrigin }
        // The URL parser reads any host whose last label is a number as IPv4, accepting hex, octal
        // and short forms and rewriting them. Only the form it would print is accepted here.
        let isHexNumber = last.hasPrefix("0x") && last.dropFirst(2).utf8.allSatisfy { isLowerAlphanumeric($0) && ($0 < UInt8(ascii: "g")) }
        if last.utf8.allSatisfy({ (0x30...0x39).contains($0) }) || isHexNumber {
            guard labels.count == 4, labels.allSatisfy({ label in
                guard label.utf8.allSatisfy({ (0x30...0x39).contains($0) }), label.count <= 3, let value = Int(label) else { return false }
                return value <= 255 && String(value) == label
            }) else { throw HubError.invalidOrigin }
        }
        return host
    }

    /// Parses `[...]` and prints it the way the URL standard serialises an IPv6 host.
    private static func ipv6(_ text: Substring) throws -> String {
        guard text.hasSuffix("]"), let pieces = ipv6Pieces(Array(text.dropFirst().dropLast().utf8)) else { throw HubError.invalidOrigin }

        // Compress the first longest run of two or more zero pieces.
        var best: Range<Int>?
        var index = 0
        while index < 8 {
            guard pieces[index] == 0 else { index += 1; continue }
            var end = index
            while end < 8, pieces[end] == 0 { end += 1 }
            if end - index >= 2, end - index > (best?.count ?? 0) { best = index..<end }
            index = end
        }
        var out = "["
        index = 0
        while index < 8 {
            if let best, index == best.lowerBound {
                out += index == 0 ? "::" : ":"
                index = best.upperBound
                continue
            }
            out += String(pieces[index], radix: 16)
            if index < 7 { out += ":" }
            index += 1
        }
        return out + "]"
    }

    /// The URL standard's IPv6 parser, step for step. `inet_pton` is not used because it is more
    /// forgiving (it takes `::ffff:192.168.01.5`), and this must never accept what the hub rejects.
    private static func ipv6Pieces(_ input: [UInt8]) -> [UInt16]? {
        func hex(_ byte: UInt8) -> UInt16? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt16(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }
        func digit(_ byte: UInt8?) -> UInt16? {
            guard let byte, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            return UInt16(byte - UInt8(ascii: "0"))
        }
        let colon = UInt8(ascii: ":"), dot = UInt8(ascii: ".")
        var address = [UInt16](repeating: 0, count: 8)
        var pieceIndex = 0, pointer = 0
        var compress: Int?
        var current: UInt8? { pointer < input.count ? input[pointer] : nil }

        if current == colon {
            guard pointer + 1 < input.count, input[pointer + 1] == colon else { return nil }
            pointer += 2
            pieceIndex += 1
            compress = pieceIndex
        }
        while current != nil {
            guard pieceIndex < 8 else { return nil }
            if current == colon {
                guard compress == nil else { return nil }
                pointer += 1
                pieceIndex += 1
                compress = pieceIndex
                continue
            }
            var value: UInt16 = 0, length = 0
            while length < 4, let nibble = current.flatMap(hex) {
                value = value * 0x10 + nibble
                pointer += 1
                length += 1
            }
            if current == dot {
                // An embedded IPv4 address fills the last two pieces.
                guard length > 0, pieceIndex <= 6 else { return nil }
                pointer -= length
                var numbersSeen = 0
                while current != nil {
                    if numbersSeen > 0 {
                        guard current == dot, numbersSeen < 4 else { return nil }
                        pointer += 1
                    }
                    guard var part = digit(current) else { return nil }
                    pointer += 1
                    while let next = digit(current) {
                        // No leading zeros, nothing above 255.
                        guard part != 0 else { return nil }
                        part = part * 10 + next
                        guard part <= 255 else { return nil }
                        pointer += 1
                    }
                    address[pieceIndex] = address[pieceIndex] * 0x100 + part
                    numbersSeen += 1
                    if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
                }
                guard numbersSeen == 4 else { return nil }
                break
            } else if current == colon {
                pointer += 1
                guard current != nil else { return nil }
            } else if current != nil {
                return nil
            }
            address[pieceIndex] = value
            pieceIndex += 1
        }
        if let compress {
            var swaps = pieceIndex - compress
            pieceIndex = 7
            while pieceIndex != 0, swaps > 0 {
                address.swapAt(pieceIndex, compress + swaps - 1)
                pieceIndex -= 1
                swaps -= 1
            }
        } else if pieceIndex != 8 {
            return nil
        }
        return address
    }

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

extension HubOrigin: CustomStringConvertible {
    public var description: String { string }
}

extension HubOrigin: Codable {
    /// Stored as its string. Only the canonical form decodes, so a stored value cannot drift from
    /// the origin the hub signs.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        try self.init(text, allowTrailingSlash: false)
        guard string == text else { throw HubError.invalidOrigin }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
