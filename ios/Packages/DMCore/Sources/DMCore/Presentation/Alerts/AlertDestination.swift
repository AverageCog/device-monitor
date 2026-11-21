import Foundation

/// Where the hub is willing to deliver alerts: an ntfy server or a webhook URL (`httpUrl` in
/// alerts.js).
///
/// The hub reads an address with JavaScript's `URL`, so this follows the same parsing rules (the
/// WHATWG URL Standard, for http and https): "https:example.com" is fine, "http://0x7f.1" is
/// 127.0.0.1. It then refuses anything but http(s), addresses with a user name or password, and
/// hosts it will not post to: localhost, loopback, link-local and cloud-metadata addresses.
/// Private network addresses are allowed (a self-hosted ntfy is a legitimate setup).
public enum AlertDestination {
    public enum Problem: Error, Sendable, Hashable, CaseIterable {
        /// Not an absolute URL, or one with an impossible host or port.
        case notAnAddress
        /// A scheme other than http or https.
        case notHTTP
        /// A user name or password in the address.
        case hasCredentials
        /// localhost, loopback, link-local or a metadata address.
        case blockedHost

        /// A sentence for the field's error line.
        public var message: String {
            switch self {
            case .notAnAddress: "Enter a full address, like https://example.com/hook."
            case .notHTTP: "The address must start with http:// or https://."
            case .hasCredentials: "Leave the user name and password out of the address."
            case .blockedHost: "The hub does not deliver to this computer itself or to link-local addresses."
            }
        }
    }

    /// The address as the hub stores it (lower-case host, default port and one trailing slash
    /// dropped), or nil when it refuses it.
    public static func normalized(_ text: String) -> String? {
        try? check(text).get()
    }

    /// Why the hub refuses the address, or nil when it accepts it.
    public static func problem(with text: String) -> Problem? {
        if case .failure(let problem) = check(text) { return problem }
        return nil
    }

    // const httpUrl = s => { … }
    static func check(_ text: String) -> Result<String, Problem> {
        guard let url = ParsedURL(text) else { return .failure(.notAnAddress) }
        guard url.scheme == "http" || url.scheme == "https" else { return .failure(.notHTTP) }
        guard !url.hasCredentials else { return .failure(.hasCredentials) }
        guard !isBlocked(url.host) else { return .failure(.blockedHost) }
        // u.href.replace(/\/$/, '')
        let href = url.href
        return .success(href.hasSuffix("/") ? String(href.dropLast()) : href)
    }

    // BLOCKED_HOST(h) || h === 'localhost' || h.endsWith('.localhost'), with isBlockedAddress.
    private static func isBlocked(_ host: ParsedURL.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isBlocked(ipv4: address)
        case .ipv6:
            // isBlockedAddress judges the address as URL writes it, without the brackets.
            var address = String(ParsedURL.serialize(host).dropFirst().dropLast())
            if address == "fd00:ec2::254" { return true }   // a cloud's metadata service
            if address.hasPrefix("::ffff:") {
                // Two groups after it are an IPv4 address (::ffff:7f00:1 is 127.0.0.1). Anything
                // else goes on without the prefix, so "::ffff:fe80:1:2" is refused for its "fe80".
                address.removeFirst(7)
                let groups = address.split(separator: ":", omittingEmptySubsequences: false).map { UInt32($0, radix: 16) }
                if groups.count == 2, let high = groups[0], let low = groups[1] {
                    return isBlocked(ipv4: high << 16 | low)
                }
            }
            return address == "::1" || address == "::" || startsLikeLinkLocal(address)   // loopback, unspecified, link-local
        case .domain(let name):
            return name == "localhost" || name.hasSuffix(".localhost") || startsLikeLinkLocal(name)
        }
    }

    /// `/^fe[89ab]/`: how the hub spots fe80::/10. It runs the test on whatever the host is
    /// written as, so it also catches "fe8::1", names like "feature.example.com", and what is
    /// left of an address once a leading "::ffff:" is taken off.
    private static func startsLikeLinkLocal(_ host: String) -> Bool {
        let start = Array(host.utf8.prefix(3))
        return start.count == 3 && start[0] == UInt8(ascii: "f") && start[1] == UInt8(ascii: "e") && "89ab".utf8.contains(start[2])
    }

    private static func isBlocked(ipv4 address: UInt32) -> Bool {
        let x = address >> 24, y = (address >> 16) & 0xff
        return x == 0 || x == 127 || (x == 169 && y == 254)
    }
}

/// An absolute URL with a host, parsed and written the way JavaScript's `URL` does it. Only what
/// `httpUrl` looks at is kept apart; path, query and fragment are carried along already encoded.
struct ParsedURL {
    enum Host: Equatable {
        case domain(String)
        case ipv4(UInt32)
        /// Eight 16-bit pieces.
        case ipv6([UInt16])
    }

    let scheme: String
    let hasCredentials: Bool
    let host: Host
    /// Nil for the scheme's default port.
    let port: Int?
    /// Starts with "/".
    let path: String
    let query: String?
    let fragment: String?

    var href: String {
        var out = scheme + "://" + Self.serialize(host)
        if let port { out += ":\(port)" }
        out += path
        if let query { out += "?" + query }
        if let fragment { out += "#" + fragment }
        return out
    }

    private static let defaultPorts = ["http": 80, "https": 443]

    init?(_ text: String) {
        // Leading and trailing C0 controls and spaces go; tabs and newlines go wherever they are.
        var input = Array(text.unicodeScalars)
        while let first = input.first, first.value <= 0x20 { input.removeFirst() }
        while let last = input.last, last.value <= 0x20 { input.removeLast() }
        input.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }

        // Scheme: a letter, then letters, digits, "+", "-" or ".", up to a colon.
        guard let first = input.first, Self.isAlpha(first) else { return nil }
        guard let colon = input.firstIndex(of: ":"),
              input[..<colon].allSatisfy({ Self.isAlpha($0) || Self.isDigit($0) || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        let scheme = String(String.UnicodeScalarView(input[..<colon])).lowercased()
        self.scheme = scheme
        var rest = input[(colon + 1)...]

        guard let defaultPort = Self.defaultPorts[scheme] else {
            // Some other scheme: httpUrl turns it down whatever follows, so the rest is not read.
            hasCredentials = false
            host = .domain("")
            port = nil
            path = String(String.UnicodeScalarView(rest))
            query = nil
            fragment = nil
            return
        }

        // A special scheme takes any number of slashes and backslashes before the authority.
        while let next = rest.first, next == "/" || next == "\\" { rest.removeFirst() }
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "\\" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        rest = rest[authorityEnd...]

        // Everything up to the last "@" is "user:password"; "@" and ":@" carry neither.
        if let at = authority.lastIndex(of: "@") {
            let userinfo = authority[..<at]
            hasCredentials = !(userinfo.isEmpty || (userinfo.count == 1 && userinfo.first == ":"))
            authority = authority[(at + 1)...]
        } else {
            hasCredentials = false
        }

        // Host and port: the first colon outside brackets starts the port.
        var hostEnd = authority.endIndex, inBrackets = false
        for index in authority.indices {
            let c = authority[index]
            if c == "[" { inBrackets = true } else if c == "]" { inBrackets = false } else if c == ":" && !inBrackets {
                hostEnd = index
                break
            }
        }
        guard hostEnd > authority.startIndex, let host = Self.parseHost(Array(authority[..<hostEnd])) else { return nil }
        self.host = host
        if hostEnd < authority.endIndex {
            let digits = authority[authority.index(after: hostEnd)...]
            guard digits.allSatisfy(Self.isDigit) else { return nil }
            var value = 0
            for digit in digits {
                value = value * 10 + Int(digit.value - 48)
                if value > 65535 { return nil }
            }
            port = digits.isEmpty || value == defaultPort ? nil : value
        } else {
            port = nil
        }

        // Path, query, fragment.
        let fragmentStart = rest.firstIndex(of: "#")
        let beforeFragment = rest[..<(fragmentStart ?? rest.endIndex)]
        let queryStart = beforeFragment.firstIndex(of: "?")
        path = Self.normalizePath(Array(beforeFragment[..<(queryStart ?? beforeFragment.endIndex)]))
        query = queryStart.map { Self.percentEncode(Array(beforeFragment[beforeFragment.index(after: $0)...]), keeping: Self.isQuerySafe) }
        fragment = fragmentStart.map { Self.percentEncode(Array(rest[rest.index(after: $0)...]), keeping: Self.isFragmentSafe) }
    }

    // MARK: Host

    /// The host parser, for a special scheme.
    private static func parseHost(_ input: [Unicode.Scalar]) -> Host? {
        if input.first == "[" {
            guard input.last == "]", input.count >= 2 else { return nil }
            return parseIPv6(Array(input[1..<(input.count - 1)])).map(Host.ipv6)
        }
        guard let decoded = percentDecode(input) else { return nil }
        guard let domain = domainToASCII(decoded), !domain.isEmpty else { return nil }
        // Forbidden domain code points.
        for scalar in domain.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7f || "#/:<>?@[\\]^|%".unicodeScalars.contains(scalar) { return nil }
        }
        if endsInANumber(domain) { return parseIPv4(domain).map(Host.ipv4) }
        return .domain(domain)
    }

    /// Percent-decodes to text. Bytes that are not UTF-8 would become U+FFFD in a browser; such a
    /// host is no name anyone can resolve, so it is turned down here.
    private static func percentDecode(_ input: [Unicode.Scalar]) -> String? {
        var bytes: [UInt8] = []
        var index = 0
        while index < input.count {
            let scalar = input[index]
            if scalar == "%", index + 2 < input.count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                bytes.append(UInt8(high * 16 + low))
                index += 3
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                index += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Domain to ASCII: lower case for ASCII names; names in other scripts go through the system's
    /// IDNA (the same UTS #46 processing a browser applies).
    private static func domainToASCII(_ domain: String) -> String? {
        if domain.unicodeScalars.allSatisfy(\.isASCII) { return domain.lowercased() }
        // Foundation encodes the host of a URL it parses. Parts of the name that are not letters
        // could confuse that parse, and no real name has them, so only plain names are passed on.
        let special = CharacterSet(charactersIn: "#/:<>?@[\\]^|% \"'`{}")
        guard domain.unicodeScalars.allSatisfy({ !special.contains($0) && $0.value > 0x20 && $0.value != 0x7f }) else { return nil }
        guard let host = URLComponents(string: "https://" + domain + "/")?.encodedHost, !host.isEmpty,
              host.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return host.lowercased()
    }

    private static func endsInANumber(_ domain: String) -> Bool {
        var parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        if parts.last == "" {
            if parts.count == 1 { return false }
            parts.removeLast()
        }
        guard let last = parts.last else { return false }
        if !last.isEmpty && last.unicodeScalars.allSatisfy(isDigit) { return true }
        return parseIPv4Number(last) != nil
    }

    /// One part of a dotted address: decimal, octal with a leading 0, or hex with 0x.
    private static func parseIPv4Number(_ part: Substring) -> UInt64? {
        guard !part.isEmpty else { return nil }
        var digits = Substring(part), radix: UInt64 = 10
        if digits.count >= 2, digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count >= 2, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        var value: UInt64 = 0
        for scalar in digits.unicodeScalars {
            guard let digit = hexValue(scalar), UInt64(digit) < radix else { return nil }
            // More than 32 bits is refused by the caller; stop growing before 64 overflow.
            value = min(value * radix + UInt64(digit), 1 << 40)
        }
        return value
    }

    private static func parseIPv4(_ domain: String) -> UInt32? {
        var parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        if parts.last == "", parts.count > 1 { parts.removeLast() }
        guard parts.count <= 4 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard let number = parseIPv4Number(part) else { return nil }
            numbers.append(number)
        }
        guard let last = numbers.last, numbers.dropLast().allSatisfy({ $0 <= 255 }) else { return nil }
        // The last part fills whatever the others leave: 256^(5 - count).
        guard last < (UInt64(1) << (8 * UInt64(5 - numbers.count))) else { return nil }
        var address = last
        for (index, number) in numbers.dropLast().enumerated() { address += number << (8 * UInt64(3 - index)) }
        return UInt32(address)
    }

    /// The IPv6 parser of the URL Standard, embedded IPv4 and all.
    private static func parseIPv6(_ input: [Unicode.Scalar]) -> [UInt16]? {
        var address = [UInt16](repeating: 0, count: 8)
        var pieceIndex = 0, compress: Int?, pointer = 0
        func c(_ offset: Int = 0) -> Unicode.Scalar? {
            pointer + offset < input.count ? input[pointer + offset] : nil
        }
        if c() == ":" {
            guard c(1) == ":" else { return nil }
            pointer += 2
            pieceIndex += 1
            compress = pieceIndex
        }
        while c() != nil {
            guard pieceIndex < 8 else { return nil }
            if c() == ":" {
                guard compress == nil else { return nil }
                pointer += 1
                pieceIndex += 1
                compress = pieceIndex
                continue
            }
            var value = 0, length = 0
            while length < 4, let digit = c().flatMap(hexValue) {
                value = value * 16 + digit
                pointer += 1
                length += 1
            }
            if c() == "." {
                // The rest is a dotted IPv4 address taking the last two pieces.
                guard length > 0 else { return nil }
                pointer -= length
                guard pieceIndex <= 6 else { return nil }
                var numbersSeen = 0
                while c() != nil {
                    var ipv4Piece: Int?
                    if numbersSeen > 0 {
                        guard c() == ".", numbersSeen < 4 else { return nil }
                        pointer += 1
                    }
                    guard let start = c(), isDigit(start) else { return nil }
                    while let digit = c(), isDigit(digit) {
                        let number = Int(digit.value - 48)
                        if let current = ipv4Piece {
                            guard current != 0 else { return nil }   // no leading zeros
                            ipv4Piece = current * 10 + number
                        } else {
                            ipv4Piece = number
                        }
                        guard (ipv4Piece ?? 0) <= 255 else { return nil }
                        pointer += 1
                    }
                    address[pieceIndex] = address[pieceIndex] * 0x100 + UInt16(ipv4Piece ?? 0)
                    numbersSeen += 1
                    if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
                }
                guard numbersSeen == 4 else { return nil }
                break
            } else if c() == ":" {
                pointer += 1
                guard c() != nil else { return nil }
            } else if c() != nil {
                return nil
            }
            address[pieceIndex] = UInt16(value)
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

    static func serialize(_ host: Host) -> String {
        switch host {
        case .domain(let name):
            return name
        case .ipv4(let address):
            return (0..<4).map { String((address >> (8 * UInt32(3 - $0))) & 0xff) }.joined(separator: ".")
        case .ipv6(let pieces):
            // The first longest run of two or more zero pieces becomes "::".
            var best: (start: Int, length: Int)?
            var index = 0
            while index < 8 {
                guard pieces[index] == 0 else {
                    index += 1
                    continue
                }
                var end = index
                while end < 8, pieces[end] == 0 { end += 1 }
                if end - index > 1, end - index > (best?.length ?? 0) { best = (index, end - index) }
                index = end
            }
            var out = "[", ignoring = false
            for position in 0..<8 {
                if ignoring && pieces[position] == 0 { continue }
                ignoring = false
                if best?.start == position {
                    out += position == 0 ? "::" : ":"
                    ignoring = true
                    continue
                }
                out += String(pieces[position], radix: 16)
                if position != 7 { out += ":" }
            }
            return out + "]"
        }
    }

    // MARK: Path, query, fragment

    /// The path state: backslashes are slashes, "." and ".." (also spelled %2e) are resolved, and
    /// what a path may not hold is percent-encoded.
    private static func normalizePath(_ input: [Unicode.Scalar]) -> String {
        var segments: [String] = []
        let pieces = input.split(omittingEmptySubsequences: false) { $0 == "/" || $0 == "\\" }
        // The split's first piece is what precedes the leading slash: nothing.
        for (index, piece) in pieces.enumerated().dropFirst(input.isEmpty ? pieces.count : 1) {
            let raw = String(String.UnicodeScalarView(piece)).lowercased()
            let isLast = index == pieces.count - 1
            if raw == ".." || raw == ".%2e" || raw == "%2e." || raw == "%2e%2e" {
                if !segments.isEmpty { segments.removeLast() }
                if isLast { segments.append("") }
            } else if raw == "." || raw == "%2e" {
                if isLast { segments.append("") }
            } else {
                segments.append(percentEncode(Array(piece), keeping: isPathSafe))
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func percentEncode(_ input: [Unicode.Scalar], keeping isSafe: (Unicode.Scalar) -> Bool) -> String {
        var out = ""
        for scalar in input {
            if isSafe(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += "%" + (byte < 16 ? "0" : "") + String(byte, radix: 16, uppercase: true) }
            }
        }
        return out
    }

    // The C0 control percent-encode set is everything outside U+0020...U+007E.
    private static func isFragmentSafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x20 && scalar.value < 0x7f && !"\"<>`".unicodeScalars.contains(scalar)
    }

    // The special-query percent-encode set.
    private static func isQuerySafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x20 && scalar.value < 0x7f && !"\"#<>'".unicodeScalars.contains(scalar)
    }

    // The path percent-encode set.
    private static func isPathSafe(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x20 && scalar.value < 0x7f && !"\"#<>?^`{}".unicodeScalars.contains(scalar)
    }

    // MARK: Characters

    private static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 48...57: Int(scalar.value) - 48
        case 65...70: Int(scalar.value) - 55
        case 97...102: Int(scalar.value) - 87
        default: nil
        }
    }
}
