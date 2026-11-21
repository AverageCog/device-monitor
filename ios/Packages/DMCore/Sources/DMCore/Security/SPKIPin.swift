import CryptoKit
import Foundation

/// The hub's TLS identity as the desktop app pins it: base64 of SHA-256 over the leaf certificate's
/// SubjectPublicKeyInfo. Port of `publicKeyPin()` in `transport.js`.
public enum SPKIPin {
    public enum ParseError: Error, Equatable, Sendable {
        /// The bytes are not one well-formed DER X.509 certificate.
        case malformedCertificate
    }

    /// The pin of a DER-encoded X.509 certificate.
    public static func pin(certificateDER: Data) throws -> String {
        pin(subjectPublicKeyInfo: try subjectPublicKeyInfo(certificateDER: certificateDER))
    }

    /// The pin of an already extracted SubjectPublicKeyInfo.
    public static func pin(subjectPublicKeyInfo: Data) -> String {
        Data(SHA256.hash(data: subjectPublicKeyInfo)).base64EncodedString()
    }

    /// `[A-Za-z0-9+/]{43}=`, the only shape a SHA-256 pin can take (`desktopTrust()` in `transport.js`).
    public static func isValid(_ pin: String) -> Bool {
        let bytes = Array(pin.utf8)
        guard bytes.count == 44, bytes[43] == UInt8(ascii: "=") else { return false }
        return bytes[..<43].allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"): true
            default: false
            }
        }
    }

    /// The SubjectPublicKeyInfo exactly as it is encoded inside the certificate.
    ///
    /// The bytes are sliced out of TBSCertificate rather than re-encoded from a `SecKey`, so every
    /// key type the hub may use (RSA, EC, Ed25519) hashes to the value Node computes.
    public static func subjectPublicKeyInfo(certificateDER: Data) throws -> Data {
        let der = DERReader([UInt8](certificateDER))
        do {
            // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
            let certificate = try der.element(in: 0..<der.count, tag: DERReader.sequence)
            guard certificate.end == der.count else { throw DERReader.Failure.malformed }
            let tbs = try der.element(in: certificate.content, tag: DERReader.sequence)
            let algorithm = try der.element(in: tbs.end..<certificate.content.upperBound, tag: DERReader.sequence)
            let signature = try der.element(in: algorithm.end..<certificate.content.upperBound, tag: DERReader.bitString)
            guard signature.end == certificate.content.upperBound else { throw DERReader.Failure.malformed }

            // TBSCertificate ::= SEQUENCE { [0] version DEFAULT v1, serialNumber, signature, issuer,
            //   validity, subject, subjectPublicKeyInfo, [1] issuerUniqueID?, [2] subjectUniqueID?, [3] extensions? }
            var cursor = tbs.content.lowerBound
            let limit = tbs.content.upperBound
            if try der.peekTag(in: cursor..<limit) == 0xA0 {
                let version = try der.element(in: cursor..<limit, tag: 0xA0)
                let number = try der.element(in: version.content, tag: DERReader.integer)
                guard number.end == version.content.upperBound, number.content.count == 1,
                      der[number.content.lowerBound] <= 2 else { throw DERReader.Failure.malformed }
                cursor = version.end
            }
            for tag in [DERReader.integer, DERReader.sequence, DERReader.sequence, DERReader.sequence, DERReader.sequence] {
                cursor = try der.element(in: cursor..<limit, tag: tag).end
            }
            let spki = try der.element(in: cursor..<limit, tag: DERReader.sequence)

            // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
            let keyAlgorithm = try der.element(in: spki.content, tag: DERReader.sequence)
            _ = try der.element(in: keyAlgorithm.content, tag: DERReader.objectIdentifier)
            let key = try der.element(in: keyAlgorithm.end..<spki.content.upperBound, tag: DERReader.bitString)
            guard key.end == spki.content.upperBound, key.content.count >= 2,
                  der[key.content.lowerBound] == 0 else { throw DERReader.Failure.malformed }

            // What follows must still be well-formed, in order and inside TBSCertificate.
            cursor = spki.end
            var lastNumber: UInt8 = 0
            while cursor < limit {
                let tag = try der.peekTag(in: cursor..<limit)
                let number = tag & 0x1F
                guard tag & 0xC0 == 0x80, (1...3).contains(number), number > lastNumber else { throw DERReader.Failure.malformed }
                lastNumber = number
                cursor = try der.element(in: cursor..<limit, tag: tag).end
            }
            return Data(der.bytes[spki.start..<spki.end])
        } catch {
            throw ParseError.malformedCertificate
        }
    }
}

/// A minimal DER reader: definite lengths only, minimal length encoding, single-byte tags, and
/// every access checked against the enclosing element. It never reads outside its buffer.
struct DERReader {
    enum Failure: Error { case malformed }

    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let objectIdentifier: UInt8 = 0x06
    static let sequence: UInt8 = 0x30

    struct Element {
        let tag: UInt8
        /// Offset of the tag byte.
        let start: Int
        /// Offsets of the value bytes.
        let content: Range<Int>
        /// Offset just past the element.
        var end: Int { content.upperBound }
    }

    let bytes: [UInt8]
    var count: Int { bytes.count }

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    subscript(offset: Int) -> UInt8 { bytes[offset] }

    private func checked(_ range: Range<Int>) throws -> Range<Int> {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw Failure.malformed }
        return range
    }

    func peekTag(in range: Range<Int>) throws -> UInt8 {
        let range = try checked(range)
        guard !range.isEmpty else { throw Failure.malformed }
        return bytes[range.lowerBound]
    }

    /// Reads the element that starts at `range.lowerBound` and must fit inside `range`.
    func element(in range: Range<Int>, tag expected: UInt8) throws -> Element {
        let range = try checked(range)
        var offset = range.lowerBound
        guard range.upperBound - offset >= 2 else { throw Failure.malformed }
        let tag = bytes[offset]
        // High-tag-number form never appears in the parts of a certificate read here.
        guard tag == expected, tag & 0x1F != 0x1F else { throw Failure.malformed }
        offset += 1
        let first = bytes[offset]
        offset += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let octets = Int(first & 0x7F)
            // 0x80 is BER's indefinite length; four octets already covers 4 GiB.
            guard (1...4).contains(octets), range.upperBound - offset >= octets, bytes[offset] != 0 else { throw Failure.malformed }
            for _ in 0..<octets {
                length = length << 8 | Int(bytes[offset])
                offset += 1
            }
            // DER requires the shortest form.
            guard length >= 0x80 else { throw Failure.malformed }
        }
        guard length <= range.upperBound - offset else { throw Failure.malformed }
        return Element(tag: tag, start: range.lowerBound, content: offset..<(offset + length))
    }
}
