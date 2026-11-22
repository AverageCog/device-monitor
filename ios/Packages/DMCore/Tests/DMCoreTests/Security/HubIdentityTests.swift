import CryptoKit
import Foundation
import Testing
@testable import DMCore

/// Vectors written by `desktop-identity.js` itself (`Fixtures/transport/generate-fixtures.cjs`).
@Suite struct HubIdentityTests {
    struct Vectors: Decodable {
        struct Digest: Decodable { let token: String; let digest: String }
        struct Key: Decodable {
            let agent: String
            let client: String
            let key: String?
            let proofSecret: String?
            let clientSecret: String?
        }
        struct Mac: Decodable { let key: String; let role: String; let fields: [String]; let json: String; let mac: String }

        let digests: [Digest]
        let keys: [Key]
        let macs: [Mac]
    }

    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Fixture.data("transport/identity-vectors.json"))
    }

    static func bytes(hex: String) -> Data {
        let digits = Array(hex.utf8)
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)! })
    }

    static func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { HubIdentity.hex(Array($0)) }
    }

    @Test func credentialDigestMatches() throws {
        let rows = try Self.vectors().digests
        #expect(rows.count >= 20)
        for row in rows {
            #expect(HubIdentity.credentialDigest(row.token) == row.digest, "token \(row.token.debugDescription)")
        }
        #expect(HubIdentity.credentialDigest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func desktopKeyMatchesAndRejectsWhatTheHubRejects() throws {
        let rows = try Self.vectors().keys
        #expect(rows.filter { $0.key == nil }.count == 9)
        #expect(rows.filter { $0.key != nil }.count == 18)
        for row in rows {
            let key = HubIdentity.desktopKey(row.agent, row.client)
            #expect(key.map(Self.hex) == row.key, "agent \(row.agent.debugDescription) client \(row.client.debugDescription)")
        }
    }

    /// A mobile enrollment derives the key from its two secrets, proof digest in the agent's place.
    @Test func proofKeyOfAMobileEnrollment() throws {
        let rows = try Self.vectors().keys.filter { $0.proofSecret != nil }
        #expect(rows.count == 6)
        for row in rows {
            let proof = try #require(row.proofSecret), client = try #require(row.clientSecret)
            #expect(HubIdentity.credentialDigest(proof) == row.agent)
            #expect(HubIdentity.credentialDigest(client) == row.client)
            #expect(Self.hex(HubIdentity.proofKey(client: client, proof: proof)) == row.key)
            // The roles are not interchangeable.
            #expect(Self.hex(HubIdentity.proofKey(client: proof, proof: client)) != row.key)
        }
    }

    @Test func jsonStringifyIsByteExact() throws {
        let rows = try Self.vectors().macs
        #expect(rows.count >= 140)
        for row in rows {
            let ours = HubIdentity.jsonStringify([row.role] + row.fields)
            // Compare bytes: String equality would forgive a normalisation difference.
            #expect(Array(ours.utf8) == Array(row.json.utf8), "\(row.json)")
        }
        #expect(HubIdentity.jsonStringify([]) == "[]")
        #expect(HubIdentity.jsonStringify(["a/b", "\u{1}\u{1F}\u{7F}", "\"\\", "\u{08}\u{0C}\n\r\t"]) == #"["a/b","\u0001\u001f\#u{7F}","\"\\","\b\f\n\r\t"]"#)
    }

    @Test func macMatchesRowByRow() throws {
        let rows = try Self.vectors().macs
        for row in rows {
            let key = SymmetricKey(data: Self.bytes(hex: row.key))
            #expect(HubIdentity.mac(key, row.role, fields: row.fields) == row.mac, "\(row.json)")
        }
        // The three forms the protocol uses, through the variadic entry point.
        let lookups = rows.filter { $0.role == "lookup" && $0.fields.isEmpty }
        let challenges = rows.filter { $0.role == "desktop" && $0.fields.count == 2 }
        let proofs = rows.filter { $0.role == "hub" && $0.fields.count == 3 && $0.fields[0].hasPrefix("https://") }
        #expect(lookups.count >= 10 && challenges.count == 10 && proofs.count == 10)
        for row in lookups {
            #expect(HubIdentity.mac(SymmetricKey(data: Self.bytes(hex: row.key)), "lookup") == row.mac)
        }
        for row in challenges {
            #expect(HubIdentity.mac(SymmetricKey(data: Self.bytes(hex: row.key)), "desktop", row.fields[0], row.fields[1]) == row.mac)
        }
        for row in proofs {
            #expect(HubIdentity.mac(SymmetricKey(data: Self.bytes(hex: row.key)), "hub", row.fields[0], row.fields[1], row.fields[2]) == row.mac)
            #expect(SPKIPin.isValid(row.fields[2]))
            #expect(HubIdentity.isValidSecret(row.fields[1]))
        }
        for row in rows {
            #expect(row.mac.utf8.count == 43 && HubIdentity.isValidSecret(row.mac))
        }
    }

    @Test func constantTimeEquals() {
        #expect(HubIdentity.constantTimeEquals("", ""))
        #expect(HubIdentity.constantTimeEquals("abc", "abc"))
        #expect(!HubIdentity.constantTimeEquals("abc", "abd"))
        #expect(!HubIdentity.constantTimeEquals("abc", "ab"))
        #expect(!HubIdentity.constantTimeEquals("abc", "abcd"))
        #expect(!HubIdentity.constantTimeEquals("Abc", "abc"))
        // Bytes, not canonical equivalence: é precomposed is not e + combining acute.
        #expect(!HubIdentity.constantTimeEquals("\u{E9}", "e\u{301}"))
        #expect("\u{E9}" == "e\u{301}")
    }

    @Test func secretsAndNonces() {
        #expect(HubIdentity.isValidSecret(String(repeating: "a", count: 43)))
        #expect(HubIdentity.isValidSecret("ABCxyz019_-" + String(repeating: "Q", count: 32)))
        for bad in ["", String(repeating: "a", count: 42), String(repeating: "a", count: 44), String(repeating: "a", count: 42) + "+",
                    String(repeating: "a", count: 42) + "/", String(repeating: "a", count: 42) + "=", String(repeating: "a", count: 42) + " ",
                    String(repeating: "é", count: 43), String(repeating: "a", count: 42) + "\n"] {
            #expect(!HubIdentity.isValidSecret(bad), "\(bad.debugDescription)")
        }
        let nonces = Set((0..<200).map { _ in HubIdentity.randomSecret() })
        #expect(nonces.count == 200)
        #expect(nonces.allSatisfy(HubIdentity.isValidSecret))
        #expect(HubIdentity.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
        #expect(HubIdentity.base64URL(Data([0xFF])) == "_w")
    }
}
