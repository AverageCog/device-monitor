import CryptoKit
import Foundation
import Testing
@testable import DMCore

/// Certificates from `Fixtures/transport/certs`, with the pin `transport.js` computes for each.
@Suite struct SPKIPinTests {
    struct Row: Decodable {
        let name: String
        let file: String
        let keyType: String
        let bytes: Int
        let pin: String
        let spki: String
    }

    static func rows() throws -> [Row] {
        try JSONDecoder().decode([Row].self, from: Fixture.data("transport/spki-pins.json"))
    }

    static func certificate(_ name: String) throws -> Data {
        try Fixture.data("transport/certs/\(name).der")
    }

    @Test func pinsMatchTheHubForEveryKeyType() throws {
        let rows = try Self.rows()
        #expect(Set(rows.map(\.keyType)) == ["rsa", "rsa-pss", "ec", "ed25519", "ed448"])
        #expect(rows.count == 12)
        for row in rows {
            let der = try Fixture.data("transport/" + row.file)
            #expect(der.count == row.bytes, "\(row.name)")
            #expect(try SPKIPin.pin(certificateDER: der) == row.pin, "\(row.name)")
            let spki = try SPKIPin.subjectPublicKeyInfo(certificateDER: der)
            #expect(HubIdentity.hex(spki) == row.spki, "\(row.name)")
            #expect(SPKIPin.pin(subjectPublicKeyInfo: spki) == row.pin, "\(row.name)")
            #expect(SPKIPin.isValid(row.pin), "\(row.name)")
        }
    }

    @Test func sameKeyInDifferentCertificatesHasTheSamePin() throws {
        let rows = Dictionary(uniqueKeysWithValues: try Self.rows().map { ($0.name, $0.pin) })
        #expect(rows["v1-ec-p256"] == rows["ec-p256"])
        #expect(rows["ca-issued-ec-p384"] == rows["ec-p384"])
        #expect(rows["huge-extension-ed25519"] == rows["ed25519"])
        #expect(rows["ec-p256"] != rows["ec-p384"])
    }

    @Test func acceptsDataThatDoesNotStartAtIndexZero() throws {
        let der = try Self.certificate("ec-p256")
        let padded = Data([0xDE, 0xAD]) + der
        let slice = padded[2...]
        #expect(slice.startIndex == 2)
        #expect(try SPKIPin.pin(certificateDER: slice) == SPKIPin.pin(certificateDER: der))
    }

    @Test func rejectsTrailingBytes() throws {
        let der = try Self.certificate("ed25519")
        #expect(throws: SPKIPin.ParseError.malformedCertificate) { try SPKIPin.pin(certificateDER: der + Data([0])) }
        #expect(throws: SPKIPin.ParseError.malformedCertificate) { try SPKIPin.pin(certificateDER: der + der) }
    }

    @Test func everyTruncationThrows() throws {
        for name in ["ed25519", "ec-p256", "v1-ec-p256", "rsa-2048", "ca-issued-ec-p384"] {
            let der = try Self.certificate(name)
            for length in 0..<der.count {
                #expect(throws: SPKIPin.ParseError.malformedCertificate, "\(name) cut to \(length)") {
                    try SPKIPin.pin(certificateDER: der.prefix(length))
                }
            }
        }
        let huge = try Self.certificate("huge-extension-ed25519")
        for length in Array(stride(from: 0, to: huge.count, by: 997)) + [huge.count - 1] {
            #expect(throws: SPKIPin.ParseError.malformedCertificate) { try SPKIPin.pin(certificateDER: huge.prefix(length)) }
        }
    }

    @Test func rejectsStructuresThatAreNotDER() throws {
        let cases: [[UInt8]] = [
            [], [0x30], [0x30, 0x00], [0x30, 0x80, 0x00, 0x00],             // empty, indefinite length
            [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF], [0x30, 0x85, 1, 0, 0, 0, 0],   // absurd and oversized lengths
            [0x30, 0x88, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            [0x30, 0x81, 0x03, 0x30, 0x01, 0x00],                             // non-minimal length
            [0x30, 0x82, 0x00, 0x03, 0x30, 0x01, 0x00],                       // leading zero in length
            [0x3F, 0x21, 0x00], [0x31, 0x00], [0x04, 0x02, 0x30, 0x00],       // high tag number, wrong tags
            [0x30, 0x06, 0x30, 0x00, 0x30, 0x00, 0x03, 0x00],                 // empty TBSCertificate
        ]
        for bytes in cases {
            #expect(throws: SPKIPin.ParseError.malformedCertificate, "\(bytes)") { try SPKIPin.pin(certificateDER: Data(bytes)) }
        }
    }

    /// A nested length that claims more than its parent holds must not read past the parent, even
    /// though the bytes exist further along in the buffer.
    @Test func innerLengthsCannotEscapeTheirParent() throws {
        var der = [UInt8](try Self.certificate("ed25519"))
        // Certificate header is 30 82 LL LL, TBSCertificate header follows at offset 4.
        #expect(der[0] == 0x30 && der[1] == 0x82 && der[4] == 0x30 && der[5] == 0x82)
        let tbsLength = Int(der[6]) << 8 | Int(der[7])
        let grown = tbsLength + 40                       // now overlaps signatureAlgorithm and the signature
        der[6] = UInt8(grown >> 8)
        der[7] = UInt8(grown & 0xFF)
        #expect(throws: SPKIPin.ParseError.malformedCertificate) { try SPKIPin.pin(certificateDER: Data(der)) }
    }

    @Test func mutatedCertificatesNeverCrashOrReadOutOfBounds() throws {
        for name in ["ed25519", "ec-p256", "v1-ec-p256", "rsa-2048", "rsa-pss-2048", "ec-p521"] {
            let original = [UInt8](try Self.certificate(name))
            let genuine = try SPKIPin.subjectPublicKeyInfo(certificateDER: Data(original))
            var survivors = 0
            for index in original.indices {
                for change: UInt8 in [0x01, 0x80, 0xFF] {
                    var bytes = original
                    bytes[index] ^= change
                    guard let spki = try? SPKIPin.subjectPublicKeyInfo(certificateDER: Data(bytes)) else { continue }
                    survivors += 1
                    // Whatever is returned is a slice of the input, never memory from elsewhere.
                    #expect(Data(bytes).range(of: spki) != nil, "\(name) byte \(index)")
                    #expect(spki.count == genuine.count, "\(name) byte \(index)")
                }
            }
            // Flips inside names, validity, key and signature bytes leave the structure intact.
            #expect(survivors > 0, "\(name)")
        }
    }

    @Test func randomBytesNeverCrash() {
        var generator = SplitMix64(seed: 0x00DE_71CE_0001)
        for _ in 0..<5000 {
            var bytes = (0..<Int(generator.next() % 200)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            // Bias towards plausible headers so the reader gets past the first byte.
            if !bytes.isEmpty, generator.next() % 2 == 0 { bytes[0] = 0x30 }
            if bytes.count > 4, generator.next() % 2 == 0 { bytes[1] = 0x82; bytes[4] = 0x30 }
            _ = try? SPKIPin.pin(certificateDER: Data(bytes))
        }
    }

    @Test func pinShape() {
        let valid = String(repeating: "A", count: 43) + "="
        #expect(SPKIPin.isValid(valid))
        #expect(SPKIPin.isValid("abcXYZ019+/" + String(repeating: "b", count: 32) + "="))
        for bad in ["", String(repeating: "A", count: 44), String(repeating: "A", count: 42) + "=", String(repeating: "A", count: 44) + "=",
                    String(repeating: "A", count: 42) + "-=", String(repeating: "A", count: 42) + "_=", String(repeating: "A", count: 42) + "==",
                    " " + String(repeating: "A", count: 42) + "=", String(repeating: "é", count: 43) + "="] {
            #expect(!SPKIPin.isValid(bad), "\(bad)")
        }
    }

    @Test func pinIsBase64OfSHA256() {
        let spki = Data("not really a key".utf8)
        #expect(SPKIPin.pin(subjectPublicKeyInfo: spki) == Data(SHA256.hash(data: spki)).base64EncodedString())
        #expect(SPKIPin.isValid(SPKIPin.pin(subjectPublicKeyInfo: spki)))
    }
}

/// Deterministic generator, so a fuzz failure can be reproduced.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
