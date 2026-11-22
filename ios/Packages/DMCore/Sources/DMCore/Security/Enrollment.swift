import Foundation

/// Everything the app keeps about the hub it is paired with. This is the Keychain item's content.
///
/// `client` is the bearer credential (hub role `client`); `proof` is the second secret, used only
/// to derive the key that verifies the hub when its TLS key rotates and never sent anywhere.
/// Every initializer and the decoder validate each field, so an `Enrollment` value is always
/// well-formed, and none of its textual representations contain either secret.
public struct Enrollment: Sendable, Equatable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidID, invalidClientCredential, invalidProofSecret, invalidPin, invalidName, unsupportedVersion
    }

    /// The hub's HTTPS origin; every request goes there and nowhere else.
    public let origin: HubOrigin
    /// The enrollment id the hub assigned (`DELETE /api/mobile/<id>` revokes it).
    public let id: String
    /// Bearer credential for the hub API.
    public let client: String
    /// Second secret of the TLS rotation proof.
    public let proof: String
    /// SPKI pin of the hub's TLS key, as verified at pairing or by the last rotation proof.
    public let pin: String
    /// The label the hub stored for this phone.
    public let name: String
    public let pairedAt: Date

    public init(origin: HubOrigin, id: String, client: String, proof: String, pin: String, name: String, pairedAt: Date) throws {
        guard Self.isValidID(id) else { throw ValidationError.invalidID }
        guard HubIdentity.isValidSecret(client) else { throw ValidationError.invalidClientCredential }
        // Two equal secrets would make the proof key derivable from the bearer alone.
        guard HubIdentity.isValidSecret(proof), proof != client else { throw ValidationError.invalidProofSecret }
        guard SPKIPin.isValid(pin) else { throw ValidationError.invalidPin }
        guard Self.isValidName(name) else { throw ValidationError.invalidName }
        self.origin = origin
        self.id = id
        self.client = client
        self.proof = proof
        self.pin = pin
        self.name = name
        // Whole milliseconds, like the hub's timestamps, so a value survives encoding unchanged.
        self.pairedAt = Date(timeIntervalSince1970: (pairedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// The same enrollment after the hub proved a new TLS key.
    public func withPin(_ pin: String) throws -> Enrollment {
        try Enrollment(origin: origin, id: id, client: client, proof: proof, pin: pin, name: name, pairedAt: pairedAt)
    }

    /// `isValidId` in `security.js`.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "-")].contains($0) }
    }

    /// The label the hub would store for `name`: control characters removed, trimmed, at most 60
    /// UTF-16 units (`cleanText` in `security.js`).
    public static func cleanName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.unicodeScalars.filter { $0.value > 0x1F && $0.value != 0x7F })
        var text = String(scalars)
        // String.prototype.trim(): Unicode white space plus line terminators and U+FEFF.
        let space = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        text = text.trimmingCharacters(in: space)
        while text.utf16.count > 60 { text.unicodeScalars.removeLast() }
        return text
    }

    private static func isValidName(_ name: String) -> Bool {
        name.utf16.count <= 120 && name.unicodeScalars.allSatisfy { $0.value > 0x1F && $0.value != 0x7F }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
        default: false
        }
    }
}

extension Enrollment: Codable {
    private enum CodingKeys: String, CodingKey {
        case version = "v", origin, id, client, proof, pin, name, pairedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else { throw ValidationError.unsupportedVersion }
        try self.init(
            origin: try container.decode(HubOrigin.self, forKey: .origin),
            id: try container.decode(String.self, forKey: .id),
            client: try container.decode(String.self, forKey: .client),
            proof: try container.decode(String.self, forKey: .proof),
            pin: try container.decode(String.self, forKey: .pin),
            name: try container.decode(String.self, forKey: .name),
            pairedAt: Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .pairedAt) / 1000)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(origin, forKey: .origin)
        try container.encode(id, forKey: .id)
        try container.encode(client, forKey: .client)
        try container.encode(proof, forKey: .proof)
        try container.encode(pin, forKey: .pin)
        try container.encode(name, forKey: .name)
        // Milliseconds since 1970, independent of any encoder date strategy.
        try container.encode((pairedAt.timeIntervalSince1970 * 1000).rounded(), forKey: .pairedAt)
    }
}

// Secrets must never reach a log line, an interpolated string, `dump()` or a crash report.
extension Enrollment: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "Enrollment(origin: \(origin), id: \(id), name: \(name), client: <redacted>, proof: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin.string, "id": id, "name": name, "client": "<redacted>", "proof": "<redacted>"], displayStyle: .struct)
    }
}
