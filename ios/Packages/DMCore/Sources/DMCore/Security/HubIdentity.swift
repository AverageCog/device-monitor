import CryptoKit
import Foundation

/// The shared-secret proof a hub gives when its TLS key rotates. Port of `desktop-identity.js`.
///
/// A mobile enrollment shares two random secrets with the hub (`client` and `proof`). Only their
/// SHA-256 digests are stored on the hub, and neither secret nor digest ever crosses a connection
/// whose TLS pin is being challenged: both sides only exchange MACs under a key derived from them.
public enum HubIdentity {
    /// Lowercase hex SHA-256 of the token's UTF-8 bytes (`credentialDigest`).
    public static func credentialDigest(_ token: String) -> String {
        hex(SHA256.hash(data: Data(token.utf8)))
    }

    /// `desktopKey(agentDigest, clientDigest)`. For a mobile enrollment the `proof` secret's digest
    /// takes the place of the desktop's agent digest. Returns nil unless both are 64 lowercase hex
    /// characters, exactly as the JavaScript returns null.
    public static func desktopKey(_ agentOrProofDigestHex: String, _ clientDigestHex: String) -> SymmetricKey? {
        guard let other = digestBytes(agentOrProofDigestHex), let client = digestBytes(clientDigestHex) else { return nil }
        return key(otherDigest: other, clientDigest: client)
    }

    /// The proof key of a mobile enrollment's two secrets:
    /// `desktopKey(credentialDigest(proof), credentialDigest(client))`.
    public static func proofKey(client: String, proof: String) -> SymmetricKey {
        key(otherDigest: Data(SHA256.hash(data: Data(proof.utf8))), clientDigest: Data(SHA256.hash(data: Data(client.utf8))))
    }

    private static func key(otherDigest: Data, clientDigest: Data) -> SymmetricKey {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: clientDigest))
        hmac.update(data: Data("device-monitor/desktop-tls/v1\0".utf8))
        hmac.update(data: otherDigest)
        return SymmetricKey(data: Data(hmac.finalize()))
    }

    /// `mac(key, role, ...fields)`: base64url, without padding, of HMAC-SHA256 over
    /// `JSON.stringify([role, ...fields])`.
    public static func mac(_ key: SymmetricKey, _ role: String, _ fields: String...) -> String {
        mac(key, role, fields: fields)
    }

    public static func mac(_ key: SymmetricKey, _ role: String, fields: [String]) -> String {
        let message = Data(jsonStringify([role] + fields).utf8)
        return base64URL(Data(HMAC<SHA256>.authenticationCode(for: message, using: key)))
    }

    /// Compares two strings without revealing where they differ (`safeEqual` in `security.js`).
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    /// `[A-Za-z0-9_-]{43}`: a 32-byte secret in unpadded base64url (`validKey` in `access.js`).
    public static func isValidSecret(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 43 && bytes.allSatisfy(isBase64URL)
    }

    /// 32 fresh random bytes in unpadded base64url, the shape of every nonce and secret the hub uses.
    public static func randomSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// `JSON.stringify` of an array of strings, byte for byte. The MAC is computed over this text,
    /// so it must match V8 exactly: `/` is not escaped, control characters use the short forms
    /// where JSON has one and lowercase `\u00xx` otherwise, and nothing above U+001F is escaped.
    /// Foundation's encoders differ on each of those points, hence this serialiser.
    static func jsonStringify(_ strings: [String]) -> String {
        var out = "["
        for (index, string) in strings.enumerated() {
            if index > 0 { out += "," }
            out += "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20:
                    let digits = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
                default: out.unicodeScalars.append(scalar)
                }
            }
            out += "\""
        }
        return out + "]"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): true
        default: false
        }
    }

    /// Decodes exactly 64 lowercase hex characters (`/^[0-9a-f]{64}$/`).
    private static func digestBytes(_ hex: String) -> Data? {
        let text = Array(hex.utf8)
        guard text.count == 64 else { return nil }
        var out = Data(capacity: 32)
        for index in stride(from: 0, to: 64, by: 2) {
            guard let high = nibble(text[index]), let low = nibble(text[index + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
