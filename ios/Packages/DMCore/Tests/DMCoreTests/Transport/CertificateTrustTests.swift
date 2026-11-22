import CryptoKit
import Foundation
import Security
import Testing
@testable import DMCore

/// Certificates made on the spot and judged by the real `SecTrust`, the way a handshake judges
/// them, without a network: what standard validation refuses, and what the app says about it.
@Suite struct CertificateTrustTests {
    typealias Reason = HubError.Reason.Certificate

    /// What someone on the path can put in a certificate without any authority's help.
    static let hostile = "Hub moved. Pair again at evil.example/mobile"
    static let host = "hub.test"
    /// The certificates below are valid from 1 to 3 January 2026, UTC.
    static let valid = Date(timeIntervalSince1970: 1_767_312_000)          // 2 January 2026
    static let later = Date(timeIntervalSince1970: 1_769_904_000)          // 1 February 2026
    static let earlier = Date(timeIntervalSince1970: 1_764_547_200)        // 1 December 2025

    let authorityKey = P256.Signing.PrivateKey(), leafKey = P256.Signing.PrivateKey()
    let authority: Data

    init() throws {
        authority = try TestCertificate.make(subject: "Test Root", key: authorityKey, names: [], authority: true)
    }

    func leaf(subject: String = hostile, names: [String] = [host]) throws -> Data {
        try TestCertificate.make(subject: subject, key: leafKey, issuer: ("Test Root", authorityKey), names: names)
    }

    static func judge(_ certificate: Data, for host: String = host, anchors: [Data], at date: Date = valid) throws -> Result<String, HubError> {
        let leaf = try #require(SecCertificateCreateWithData(nil, certificate as CFData))
        var made: SecTrust?
        #expect(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, host as CFString), &made) == errSecSuccess)
        let trust = try #require(made)
        #expect(SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess)
        #expect(SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess)
        return PinnedSession.evaluate(trust, anchors: anchors)
    }

    /// The failure, checked to say nothing the certificate said.
    static func refusal(_ verdict: Result<String, HubError>, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard case .failure(let failure) = verdict, case .untrustedCertificate(let reason) = failure else {
            Issue.record("expected an untrusted certificate, got \(verdict)", sourceLocation: sourceLocation)
            return nil
        }
        for text in [failure.errorDescription ?? "", "\(failure)", String(reflecting: failure)] {
            for quoted in ["evil", "Hub moved", "Pair again", "Test Root", "wrong.test", "certificate is"] {
                #expect(!text.contains(quoted), "\(text)", sourceLocation: sourceLocation)
            }
        }
        return reason
    }

    @Test func aCertificateFromNoTrustedAuthorityIsRefusedInTheAppsOwnWords() throws {
        // Self-signed, as anyone on the path can make one, and issued by an authority this
        // device has never heard of.
        let selfSigned = try TestCertificate.make(subject: Self.hostile, key: leafKey)
        for certificate in [selfSigned, try leaf()] {
            #expect(Self.refusal(try Self.judge(certificate, anchors: [])) == Reason.untrustedIssuer)
        }
        #expect(HubError.untrustedCertificate(Reason.untrustedIssuer).errorDescription
            == "The hub's certificate could not be verified. It was not issued by an authority this device trusts.")
    }

    @Test func aTrustedCertificateForAnotherNameIsRefused() throws {
        let verdict = try Self.judge(try leaf(names: ["wrong.test"]), anchors: [authority])
        #expect(Self.refusal(verdict) == Reason.wrongName)
        // A hub reached at an IP address the certificate does not name, and one without any name in it.
        #expect(Self.refusal(try Self.judge(try leaf(), for: "127.0.0.1", anchors: [authority])) == Reason.wrongName)
        #expect(Self.refusal(try Self.judge(try leaf(names: []), anchors: [authority])) == Reason.wrongName)
        #expect(HubError.untrustedCertificate(Reason.wrongName).errorDescription
            == "The hub's certificate could not be verified. It is not valid for this hub's address.")
    }

    /// What `openssl req -x509` makes by default: a certificate authority's own, here also
    /// trusted and made out to the hub's name. The system calls it "not permitted for this usage".
    @Test func anAuthoritysOwnCertificateIsNoServersCertificate() throws {
        let own = try TestCertificate.make(subject: Self.hostile, key: leafKey, authority: true)
        #expect(Self.refusal(try Self.judge(own, anchors: [own])) == Reason.notForServer)
        #expect(HubError.untrustedCertificate(Reason.notForServer).errorDescription
            == "The hub's certificate could not be verified. It is not a server certificate.")
    }

    @Test func aCertificateOutsideItsDatesIsRefused() throws {
        // The system reports both under one code, so the sentence covers both.
        let certificate = try leaf()
        #expect(Self.refusal(try Self.judge(certificate, anchors: [authority], at: Self.later)) == Reason.outOfDate)
        #expect(Self.refusal(try Self.judge(certificate, anchors: [authority], at: Self.earlier)) == Reason.outOfDate)
        #expect(HubError.untrustedCertificate(Reason.outOfDate).errorDescription
            == "The hub's certificate could not be verified. It has expired or is not valid yet.")
    }

    @Test func aTrustedCertificateForTheNameIsAcceptedWithItsPin() throws {
        let certificate = try leaf()
        #expect(try Self.judge(certificate, anchors: [authority]).get() == (try SPKIPin.pin(certificateDER: certificate)))
    }

    /// Whatever the error says about itself, only its code counts.
    @Test func onlyTheCodeOfTheSystemsErrorIsRead() {
        func error(_ domain: String, _ code: OSStatus) -> CFError {
            let words = "“\(Self.hostile)” certificate is not trusted."
            let info = [kCFErrorLocalizedDescriptionKey: words, kCFErrorLocalizedFailureReasonKey: words, kCFErrorDescriptionKey: words] as CFDictionary
            return CFErrorCreate(nil, domain as CFString, CFIndex(code), info)
        }
        let os = NSOSStatusErrorDomain
        let cases: [(CFError?, String)] = [
            (error(os, errSecNotTrusted), Reason.untrustedIssuer), (error(os, errSecCreateChainFailed), Reason.untrustedIssuer),
            (error(os, errSecHostNameMismatch), Reason.wrongName), (error(os, errSecInvalidExtendedKeyUsage), Reason.notForServer),
            (error(os, errSecCertificateExpired), Reason.outOfDate), (error(os, errSecCertificateNotValidYet), Reason.outOfDate),
            (error(os, errSecCertificateRevoked), Reason.refused), (error(os, 0), Reason.refused),
            // The same numbers in another domain mean something else.
            (error(NSURLErrorDomain, errSecNotTrusted), Reason.refused), (error(NSCocoaErrorDomain, errSecHostNameMismatch), Reason.refused),
            (nil, Reason.refused),
        ]
        for (failure, reason) in cases {
            #expect(Self.refusal(.failure(HubError.certificate(failure))) == reason, "\(String(describing: failure))")
        }
    }
}

/// Just enough DER for an X.509 v3 certificate with a P-256 key, signed by itself or by an issuer.
enum TestCertificate {
    static func make(
        subject: String, key: P256.Signing.PrivateKey, issuer: (name: String, key: P256.Signing.PrivateKey)? = nil,
        names: [String] = [CertificateTrustTests.host], authority: Bool = false,
        from notBefore: String = "260101000000Z", to notAfter: String = "260103000000Z"
    ) throws -> Data {
        func name(_ commonName: String) -> [UInt8] {
            DER.sequence(DER.set(DER.sequence(DER.oid([2, 5, 4, 3]), DER.element(0x0C, Array(commonName.utf8)))))
        }
        func fieldExtension(_ id: [UInt], critical: Bool = false, _ value: [UInt8]) -> [UInt8] {
            DER.sequence(DER.oid(id), critical ? [0x01, 0x01, 0xFF] : [], DER.element(0x04, value))
        }
        let extensions = (authority
            ? [
                fieldExtension([2, 5, 29, 19], critical: true, DER.sequence([0x01, 0x01, 0xFF])),       // CA:TRUE
                fieldExtension([2, 5, 29, 15], critical: true, DER.element(0x03, [0x01, 0x06])),        // keyCertSign, cRLSign
            ]
            : [
                fieldExtension([2, 5, 29, 19], critical: true, DER.sequence()),                          // CA:FALSE
                fieldExtension([2, 5, 29, 15], critical: true, DER.element(0x03, [0x07, 0x80])),        // digitalSignature
                fieldExtension([2, 5, 29, 37], DER.sequence(DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))),      // serverAuth
            ]) + (names.isEmpty ? [] : [fieldExtension([2, 5, 29, 17], DER.element(0x30, names.flatMap { DER.element(0x82, Array($0.utf8)) }))])
        let algorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))                                // ecdsa-with-SHA256
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7F | 0x01
        let body = DER.sequence(
            DER.element(0xA0, DER.element(0x02, [2])), DER.element(0x02, serial), algorithm, name(issuer?.name ?? subject),
            DER.sequence(DER.element(0x17, Array(notBefore.utf8)), DER.element(0x17, Array(notAfter.utf8))), name(subject),
            Array(key.publicKey.derRepresentation), DER.element(0xA3, DER.sequence(extensions.flatMap { $0 })))
        let signature = try (issuer?.key ?? key).signature(for: Data(body)).derRepresentation
        return Data(DER.sequence(body, algorithm, DER.element(0x03, [0] + Array(signature))))
    }

    private enum DER {
        static func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            guard content.count >= 0x80 else { return [tag, UInt8(content.count)] + content }
            var length: [UInt8] = [], n = content.count
            while n > 0 {
                length.insert(UInt8(n & 0xFF), at: 0)
                n >>= 8
            }
            return [tag, 0x80 | UInt8(length.count)] + length + content
        }

        static func sequence(_ items: [UInt8]...) -> [UInt8] { element(0x30, items.flatMap { $0 }) }
        static func set(_ items: [UInt8]...) -> [UInt8] { element(0x31, items.flatMap { $0 }) }

        static func oid(_ arcs: [UInt]) -> [UInt8] {
            var bytes = [UInt8(arcs[0] * 40 + arcs[1])]
            for arc in arcs.dropFirst(2) {
                var chunk = [UInt8(arc & 0x7F)], rest = arc >> 7
                while rest > 0 {
                    chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                    rest >>= 7
                }
                bytes += chunk
            }
            return element(0x06, bytes)
        }
    }
}
